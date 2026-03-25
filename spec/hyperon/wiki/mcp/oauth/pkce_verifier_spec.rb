# frozen_string_literal: true

require "spec_helper"
require "hyperon/wiki/mcp/oauth/pkce_verifier"

RSpec.describe Hyperon::Wiki::Mcp::OAuth::PkceVerifier do
  describe ".generate_challenge" do
    it "generates a Base64url-encoded SHA-256 challenge" do
      verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
      challenge = described_class.generate_challenge(verifier)

      # Should be a valid base64url string without padding
      expect(challenge).to match(%r{\A[A-Za-z0-9_-]+\z})
      expect(challenge).not_to include("=")
    end

    it "produces deterministic output for same input" do
      verifier = "test-verifier-12345"
      expect(described_class.generate_challenge(verifier)).to eq(described_class.generate_challenge(verifier))
    end

    it "produces different output for different inputs" do
      challenge_a = described_class.generate_challenge("verifier-a")
      challenge_b = described_class.generate_challenge("verifier-b")
      expect(challenge_a).not_to eq(challenge_b)
    end
  end

  describe ".verify" do
    let(:code_verifier) { "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk" }
    let(:code_challenge) { described_class.generate_challenge(code_verifier) }

    it "returns true for matching verifier and challenge" do
      expect(described_class.verify(
               code_verifier: code_verifier,
               code_challenge: code_challenge,
               method: "S256"
             )).to be true
    end

    it "returns false for non-matching verifier" do
      expect(described_class.verify(
               code_verifier: "wrong-verifier",
               code_challenge: code_challenge,
               method: "S256"
             )).to be false
    end

    it "returns false for non-matching challenge" do
      expect(described_class.verify(
               code_verifier: code_verifier,
               code_challenge: "wrong-challenge-value-that-is-same-len",
               method: "S256"
             )).to be false
    end

    it "defaults method to S256" do
      expect(described_class.verify(
               code_verifier: code_verifier,
               code_challenge: code_challenge
             )).to be true
    end

    it "returns false for unsupported method" do
      expect(described_class.verify(
               code_verifier: code_verifier,
               code_challenge: code_challenge,
               method: "plain"
             )).to be false
    end

    it "returns false for nil code_verifier" do
      expect(described_class.verify(
               code_verifier: nil,
               code_challenge: code_challenge
             )).to be false
    end

    it "returns false for empty code_verifier" do
      expect(described_class.verify(
               code_verifier: "",
               code_challenge: code_challenge
             )).to be false
    end

    it "returns false for nil code_challenge" do
      expect(described_class.verify(
               code_verifier: code_verifier,
               code_challenge: nil
             )).to be false
    end

    it "returns false for empty code_challenge" do
      expect(described_class.verify(
               code_verifier: code_verifier,
               code_challenge: ""
             )).to be false
    end
  end

  describe ".constant_time_compare" do
    it "returns true for equal strings" do
      expect(described_class.constant_time_compare("abc", "abc")).to be true
    end

    it "returns false for different strings of same length" do
      expect(described_class.constant_time_compare("abc", "def")).to be false
    end

    it "returns false for strings of different length" do
      # str_a and str_b have different bytesizes
      expect(described_class.constant_time_compare("ab", "abc")).to be false
    end
  end

  describe "RFC 7636 test vector" do
    # From RFC 7636 Appendix B
    it "matches the S256 test vector" do
      verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
      expected_challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

      challenge = described_class.generate_challenge(verifier)
      expect(challenge).to eq(expected_challenge)
    end
  end
end
